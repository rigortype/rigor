# frozen_string_literal: true

require_relative "../analysis/dependency_recorder"
require_relative "../reflection"

module Rigor
  module Inference
    # Issue #527 slice 0 — the single owner of one question: which RBS declaration answers
    # `method_name` on `class_name` through an ancestor the PROJECT does not declare?
    #
    # A project class is usually absent from the RBS environment, so the declaration that decides the
    # question is written about an ancestor the project does not declare — the `< StandardError`
    # superclass, the `include Comparable` mixin, `< ::StringScanner`. `Scope#external_ancestor_name_candidates`
    # gathers those as-written names breadth-first over the project ancestry; this module resolves each
    # group against the RBS environment and reports WHICH declaration answered, not merely that one did.
    #
    # The logic existed twice before: `ExpressionTyper#rbs_ancestor_answers?` asked it as a boolean (the
    # implicit-self binding veto of issue #633 / ADR-110), and the dispatch side of #527 needs the same
    # walk but wants the definition and its owner so it can dispatch there. Two copies of an MRO cut-off
    # rule is one copy too many, so the boolean is now `!resolve(...).nil?`.
    #
    # The one thing the consumers do NOT share is the ADR-46 cross-file edge, and that is
    # `record_dependencies:`. The implicit-self veto genuinely READ the ancestor's declaration sites to
    # decide a binding, so its walk records them. A dispatch lookup asking "does some ancestor happen to
    # declare this?" did not, and filing an edge for it would mislabel the lookup as an ancestry edge —
    # which is why `RbsDispatch.each_source_ancestor_candidate` read the raw discovery tables instead of
    # this walk. The suppression is #992's {Analysis::DependencyRecorder.withhold} around the walk, NOT
    # a flag threaded into `Scope`: an ADR-2 plugin-facing bypass of dependency recording would produce
    # a silently stale warm cache that no diagnostic diff can show.
    #
    # There is deliberately NO memo here. The dispatch consumer this module is being extracted FOR does
    # not exist yet, and a memo keyed on the tables this slice happens to name would be keyed on less
    # than the walk reads — `Scope#resolve_ancestor_class_name` consults `discovered_def_nodes` and
    # `discovered_methods` through `known_user_class?`, and `ancestor_name_candidates` reads
    # `discovered_header_nestings`. The slice that brings the hot path brings the memo, keyed on what
    # that consumer actually reads.
    module ExternalAncestorResolution
      # The owner a name must PRECEDE for its declaration to win an MRO. See {declared_before_object?}.
      OBJECT_OWNER = "Object"
      private_constant :OBJECT_OWNER

      module_function

      # Resolves `method_name` on `class_name` against the RBS environment, through the project's
      # ancestry where `class_name` itself is absent from RBS.
      #
      # Returns `[definition, owner_name]` — the `RBS::Definition::Method` and the name of the class the
      # walk asked it of (NOT `definition.defined_in`, which may be further up that class's own RBS
      # ancestry) — or `nil` when no ancestor answers.
      #
      # The cut-off is `::Object`, not the own class: a top-level `def` IS a private `Object` instance
      # method, the last link of every MRO, so any declared owner that comes before `::Object` wins at
      # runtime (`Exception#message`, `Array#first`, `Comparable#clamp`) while a name owned by `Object`
      # or `Kernel` themselves sits at or after that rung and contributes no evidence (#316 / #319).
      #
      # `kind` is `:instance` today. The singleton side of the walk (a module's `def self.` reached
      # through a discovered `include`, #527 slice 6) is not implemented, and declines rather than
      # guessing — which is what the engine answers there now.
      #
      # `record_dependencies: false` runs the ancestry walk under {Analysis::DependencyRecorder.withhold}
      # so its reads reach no consumer. Only the WALK is withheld: the `Reflection` lookups around it
      # read the RBS environment, which files no cross-file edge, so this suppresses exactly the intended
      # one. `withhold` is a `[yield, nil]` fast path when nothing is recording, which is every ordinary
      # run.
      #
      # `mixins: false` narrows the walk to the SUPERCLASS chain. #527 slice 1 lands `< Hash` before
      # `include Enumerable` so that slice 2's measurement stays its own, and the narrowing belongs to
      # the CALLER rather than to this module: the implicit-self veto must keep walking both edges,
      # because Ruby reaches an included module's methods too.
      # rubocop:disable-next Metrics/ParameterLists
      def resolve(class_name, method_name, kind = :instance, scope:, environment: nil, name_memo: nil,
                  record_dependencies: true, mixins: true)
        return nil if class_name.nil? || scope.nil?
        return nil unless kind == :instance

        compute(class_name, method_name, scope, environment, name_memo, record_dependencies, mixins)
      end

      # The RBS method definition for `class_name`, or nil for a class the environment does not know, a
      # name it does not declare, or a signature it cannot build. The single owner of the `rescue` —
      # a malformed third-party signature is a gap, never an exception escaping into inference.
      def method_definition(class_name, method_name, kind, scope: nil, environment: nil)
        if kind == :singleton
          Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope,
                                                                                 environment: environment)
        else
          Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope,
                                                                                environment: environment)
        end
      rescue StandardError
        nil
      end

      # True when the RBS declaration found for the name sits on `class_name` itself rather than on an
      # ancestor; mirrors `CheckRules#defined_on?` and `SigGen::Generator#declared_on_class_itself?`.
      def declared_on_class?(definition, class_name)
        return false if definition.nil?
        return false unless definition.respond_to?(:defined_in)

        defined_in = definition.defined_in
        return false if defined_in.nil?

        defined_in.to_s.delete_prefix("::") == class_name.to_s.delete_prefix("::")
      end

      # Issue #633 — true when the declaration's owner sits strictly before `::Object` in `class_name`'s
      # instance MRO, i.e. Ruby dispatches to it ahead of a top-level `def` (which is `Object`'s own
      # private instance method). The own class trivially qualifies. An owner absent from the ancestor
      # list, an unbuildable class, and an ancestry that does not reach `Object` (a `BasicObject`
      # descendant) all answer false, leaving the historical top-level binding untouched.
      def declared_before_object?(definition, class_name, scope: nil, environment: nil)
        return true if declared_on_class?(definition, class_name)
        return false if definition.nil? || !definition.respond_to?(:defined_in)

        owner = definition.defined_in
        return false if owner.nil?

        ancestors = instance_ancestor_names(class_name, scope: scope, environment: environment)
        object_index = ancestors.index(OBJECT_OWNER)
        owner_index = ancestors.index(owner.to_s.delete_prefix("::"))
        !object_index.nil? && !owner_index.nil? && owner_index < object_index
      end

      # The class's instance-side ancestors in MRO order, `::`-stripped, or `[]` for a class the RBS
      # environment does not know or cannot build. Read through the loader's accessor rather than
      # `instance_definition(...).ancestors` because that is the one wired to the ancestor-name cache and
      # marked as RIGOR'S OWN demand — ordering two ancestors is not the analysis asking whether either
      # one's methods resolve, and the `rbs.coverage` bookkeeping must not record it as such.
      def instance_ancestor_names(class_name, scope: nil, environment: nil)
        loader = rbs_loader_for(scope, environment)
        loader ? loader.ancestor_names_for(class_name.to_s) : []
      rescue StandardError
        []
      end

      def compute(class_name, method_name, scope, environment, name_memo, record_dependencies, mixins)
        kind = :instance
        own = method_definition(class_name, method_name, kind, scope: scope, environment: environment)
        if own
          own_ancestors = instance_ancestor_names(class_name, scope: scope, environment: environment)
          if declared_before_object?(own, class_name, scope: scope, environment: environment) ||
             owned_within_candidate_chain?(own, own_ancestors)
            return [own, class_name.to_s].freeze
          end
        end

        groups = ancestor_candidate_groups(scope, class_name, name_memo, record_dependencies, mixins)
        groups.each do |candidates|
          answer = first_known_candidate_answer(candidates, method_name, kind, scope, environment)
          return answer if answer
        end
        nil
      end
      private_class_method :compute

      # The first candidate spelling the RBS environment knows is the ancestor Ruby resolves; a name it
      # knows nothing about contributes no evidence either way, and a known one that does NOT answer
      # ends this group rather than falling through to a less-qualified spelling of the same name.
      def first_known_candidate_answer(candidates, method_name, kind, scope, environment)
        candidates.each do |candidate|
          ancestors = instance_ancestor_names(candidate, scope: scope, environment: environment)
          next if ancestors.empty?

          definition = method_definition(candidate, method_name, kind, scope: scope,
                                                                       environment: environment)
          return nil unless declared_before_object?(definition, candidate,
                                                    scope: scope, environment: environment) ||
                            owned_within_candidate_chain?(definition, ancestors)

          return [definition, candidate].freeze
        end
        nil
      end
      private_class_method :first_known_candidate_answer

      # The module-candidate half of the answering test (#1173 review). A module's RBS ancestry is
      # `[itself, its own includes…]` and never reaches `Object`, so {declared_before_object?} — whose
      # cut-off exists to keep an Object- / Kernel-owned declaration from outranking a top-level `def`
      # — always answers false for it: the cut-off has nothing to cut. What decides instead is that
      # the declaration came from the candidate's OWN chain: when the candidate sits in the receiver's
      # MRO, Ruby dispatches the name through exactly those ancestors, so a `defined_in` anywhere in
      # the list is the method that runs. Without this, a nearer RBS module that inherits the name
      # from its own RBS `include` read as a dead group and a FARTHER ancestor's declaration was
      # adopted in its place — `class C; include A; include B` where `B`'s RBS includes `N` answering
      # A's declaration rather than N's. The gate keeps the Object cut-off's reach: a chain that DOES
      # contain `Object` (every ordinary class candidate) is untouched.
      def owned_within_candidate_chain?(definition, ancestors)
        return false if ancestors.include?(OBJECT_OWNER)
        return false if definition.nil? || !definition.respond_to?(:defined_in)

        owner = definition.defined_in
        !owner.nil? && ancestors.include?(owner.to_s.delete_prefix("::"))
      end
      private_class_method :owned_within_candidate_chain?

      # The walk, with its ADR-46 reads attached or detached. `withhold` returns `[result, read_set]`
      # and the read set is dropped: a caller that suppresses is saying these reads are not a dependency
      # of its answer, not that they should be replayed somewhere else.
      def ancestor_candidate_groups(scope, class_name, name_memo, record_dependencies, mixins)
        memo = name_memo || {}
        if record_dependencies
          return scope.external_ancestor_name_candidates(class_name, name_memo: memo, mixins: mixins)
        end

        Analysis::DependencyRecorder.withhold do
          scope.external_ancestor_name_candidates(class_name, name_memo: memo, mixins: mixins)
        end.first
      end
      private_class_method :ancestor_candidate_groups

      def rbs_loader_for(scope, environment)
        (environment || scope&.environment)&.rbs_loader
      rescue StandardError
        nil
      end
      private_class_method :rbs_loader_for
    end
  end
end
