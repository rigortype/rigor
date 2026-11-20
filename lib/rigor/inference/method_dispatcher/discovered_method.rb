# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The discovered-method tier (v0.1.3, ADR-24): a call to a method the project's own source defines, on a class
      # the scope's `discovered_methods` table records, answers `Dynamic[top]` where no body is there to re-type.
      # `MethodDispatcher.resolve_site` asks it below the dependency-source tier and records the origin of a
      # `Dynamic` answer, so it is a call there and a member of no tier array.
      #
      # {#discovered_method_lookup} is a second entry: `MethodDispatcher.record_transitive_void_origin`, which
      # `dispatch_site` runs after `resolve_site`, keys the same table the same way.
      module DiscoveredMethod
        module_function

        # v0.1.3 — discovered-method dispatch tier. `scope` carries the `discovered_methods` table
        # built once per program by `ScopeIndexer` (a `Hash[String, Hash[Symbol, :instance |
        # :singleton]]`). When the receiver names a discovered class AND the requested method is
        # recorded for that class's appropriate kind, return `Type::Combinator.untyped` — the
        # dispatcher cannot infer a more precise return type from the bare `def` shape, but the
        # call site stops being a fail-soft hot spot.
        #
        # Returns `nil` when scope / receiver class is unavailable, when the method is not in the
        # discovered table, OR when `discovered_def_nodes` carries a re-typable body for the method
        # (so the downstream `CallLadder::UserMethod` rung can re-type the body
        # for a precise return type rather than collapsing to `Dynamic[top]` here).
        #
        # The tier does NOT gate on `rbs_class_known?`. RBS dispatch already had its turn upstream
        # and returned `nil` (otherwise we wouldn't be here). When RBS knows the class but the
        # particular method is missing from the sig — common for internal helpers and for
        # auto-generated stubs that emit `class X` without enumerating every method — falling
        # through to the user-class fallback would mistakenly fire `call.undefined-method`.
        # Honoring the discovered table here keeps the sibling-private call resolution working
        # under partial RBS coverage.
        def try_dispatch(context)
          receiver_type = context.receiver
          method_name = context.method_name
          scope = context.scope
          return nil if scope.nil?

          class_name, kind = discovered_method_lookup(receiver_type)
          return nil if class_name.nil?
          return nil unless scope.discovered_method?(class_name, method_name, kind)
          # Decline when a re-typable body is recorded for the method, so the downstream
          # `ExpressionTyper` inference tier can fold a precise return instead of collapsing to
          # `Dynamic[top]` here — instance bodies via `user_def_for`, singleton bodies (`def
          # self.x` / `module_function`) via `singleton_def_for` (module-singleton call
          # resolution, ADR-57 follow-up).
          return nil if kind == :instance && scope.user_def_for(class_name, method_name)
          return nil if kind == :singleton && scope.singleton_def_for(class_name, method_name)

          Type::Combinator.untyped
        end

        # Resolves the `(class_name, kind)` pair scope_indexer keys its `discovered_methods` table
        # on. `Nominal[X]` looks up instance methods on X; `Singleton[X]` looks up singleton
        # methods on X. Other carriers return `[nil, nil]` so the tier declines.
        def discovered_method_lookup(receiver_type)
          # #525 — the ADR-48 member carriers name their class too: a `Line = Struct.new(...) do ... end`
          # value is a StructInstance whose block-def methods are discovered under "Line".
          case receiver_type
          when Type::Nominal, Type::StructInstance, Type::DataInstance
            [receiver_type.class_name, :instance]
          when Type::Singleton, Type::StructClass, Type::DataClass
            [receiver_type.class_name, :singleton]
          else NO_DISCOVERED_LOOKUP
          end
        end

        # The shared "no discovered-method key" pair; callers destructure it (#775).
        NO_DISCOVERED_LOOKUP = [nil, nil].freeze
        private_constant :NO_DISCOVERED_LOOKUP
      end
    end
  end
end
