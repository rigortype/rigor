# frozen_string_literal: true

require "prism"
require_relative "../../type"
require_relative "synthetic_method_dispatch"
# `Scope::ResolutionChain` is left to the load order, as `declared_constructor.rb` and `rbs_dispatch.rb` leave it:
# `scope.rb` requires the typer, which requires the dispatcher, and the chain does not load ahead of `scope.rb`.

module Rigor
  module Inference
    module MethodDispatcher
      # The project-patched tier (ADR-17): a method a `pre_eval:` file patches onto a class answers from the
      # `ProjectPatchedMethods` registry the environment carries. `MethodDispatcher.resolve` asks it twice, for the
      # receiver's own class below the synthetic-method tier and, with `through_ancestors: true`, for the receiver's
      # ancestors below the discovered-method tier. It records the origin of each answer, so both are calls there and
      # members of no tier array.
      #
      # An alias whose old name no patch binds re-enters `MethodDispatcher.resolve` ({#project_patched_alias_target}),
      # the module's one call back into the dispatcher. {#explicit_non_self_receiver?} is a second entry: the
      # user-class fallback asks it too.
      module ProjectPatched
        module_function

        # ADR-17 slice 2 — project-side patched-method tier. Slice 3a uses the registry's
        # heuristic-extracted `return_type` (populated via the same
        # `Analysis::DependencySourceInference::ReturnTypeHeuristic` the ADR-10 walker uses): a
        # `def to_url; "hello"; end` patched onto `String` now resolves `s.to_url` to
        # `Dynamic[Nominal[String]]` instead of the pre-3a `Dynamic[Top]`. Falls back to
        # `Dynamic[Top]` when the heuristic declined (non-literal tail expression).
        #
        # `through_ancestors:` (issue #1708), with a scope, searches the receiver's ancestors as well, through
        # {ProjectPatchedMethods#lookup_through_ancestors}, stopping at a nearer project-source `def`. A private or
        # protected patch Ruby would not let the call reach ({ProjectPatchedMethods#callable?}) answers nothing, so
        # `1.kp` on `module Kernel; private def kp` reads as the undefined call it is.
        def try_dispatch(context, through_ancestors: false) # rubocop:disable Metrics/AbcSize
          receiver_type = context.receiver
          method_name = context.method_name
          arg_types = context.args
          block_type = context.block_type
          environment = context.environment
          call_node = context.call_node
          scope = context.scope
          return nil if environment.nil?

          registry = environment.project_patched_methods
          return nil if registry.nil? || registry.empty?

          class_name = SyntheticMethodDispatch.synthetic_method_class_name(receiver_type)
          return nil if class_name.nil?

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          entry = project_patched_entry(registry, class_name, method_name, kind, environment,
                                        scope: scope, through_ancestors: through_ancestors)
          return nil if entry.nil?

          verdict = registry.callable?(entry, explicit: explicit_non_self_receiver?(call_node),
                                              self_type: scope ? scope.self_type : :unknown,
                                              rbs_loader: environment.rbs_loader)
          return nil if verdict == false
          return Type::Combinator.untyped if verdict.nil?
          return Type::Combinator.dynamic(entry.return_type) if entry.return_type

          aliased = project_patched_alias_target(entry, receiver_type, arg_types, block_type, environment)
          aliased ? Type::Combinator.dynamic(aliased) : Type::Combinator.untyped
        end

        def project_patched_entry(registry, class_name, method_name, kind, environment, scope:, through_ancestors:)
          return registry.lookup(class_name: class_name, method_name: method_name, kind: kind) unless through_ancestors

          registry.lookup_through_ancestors(
            class_name: class_name, method_name: method_name, kind: kind, rbs_loader: environment.rbs_loader,
            source_defines: ->(owner, side) { project_source_defines?(scope, owner, method_name, side) }
          )
        end

        # Issue #1708 — does the project's own source define `method_name` on `owner` (`side` as the ancestor walk
        # reaches it), or on a module the project prepends to or includes into it? Ruby runs that `def` ahead of a
        # patch on a farther ancestor: `class Integer; def nn = "s"` beats `class Object; def nn = nil` in a
        # `pre_eval:` file. The owner's level of its {Scope::ResolutionChain} (its prepends, itself, its includes
        # and their own mixins, or a class object's singleton and its extends) holds those definers; whether one
        # of them defines the name does not depend on their order, so the chain is searched without settling it.
        def project_source_defines?(scope, owner, method_name, side)
          return false unless scope.known_user_class?(owner)

          chain = Scope::ResolutionChain.for(scope, owner, side, :methods)
          own_level_end = chain.level_starts[1] || chain.entries.size
          found = chain.search(scope, 0, own_level_end) do |entry|
            !entry.external? && source_def?(scope, entry.name, method_name, entry.side)
          end
          !found.nil?
        end

        def source_def?(scope, owner, method_name, side)
          if side == :singleton
            scope.discovered_method?(owner, method_name, :singleton) ||
              !scope.singleton_def_for(owner, method_name).nil?
          else
            scope.discovered_method?(owner, method_name, :instance) || !scope.user_def_for(owner, method_name).nil?
          end
        end

        # Issue #1702 — an alias in a `pre_eval:` patch whose old name no earlier patch binding defines
        # (`alias old_plus +` on Integer, or `alias_method :orig_succ, :succ` ahead of the patch's own `def succ`)
        # names the method the class had before the patch, so it answers what that method answers for the same
        # arguments, behind the `Dynamic` every patched method carries. The re-entry skips this tier: a later patch
        # `def` of the old name is not the body the alias copied, and the skip is also what ends an alias cycle. It
        # carries no call node or scope, so it answers a type and records nothing at the call site.
        def project_patched_alias_target(entry, receiver_type, arg_types, block_type, environment)
          return nil if entry.alias_of.nil?

          MethodDispatcher.resolve(
            receiver_type: receiver_type, method_name: entry.alias_of, arg_types: arg_types,
            block_type: block_type, environment: environment, skip_project_patched: true
          )
        end

        # True when the call node carries an explicit receiver that is not the literal `self`.
        # Such a call cannot legally dispatch to a private method, so the user-class fallback must
        # skip private signatures rather than return a confidently-wrong type. Returns false for
        # implicit-self calls and `self.`-receiver calls (both may legally reach a private method
        # in modern Ruby), and false when no `call_node` is supplied (internal dispatcher callers).
        def explicit_non_self_receiver?(call_node)
          return false if call_node.nil?
          return false unless call_node.respond_to?(:receiver)

          receiver = call_node.receiver
          return false if receiver.nil?

          !receiver.is_a?(Prism::SelfNode)
        end
      end
    end
  end
end
