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
    # Two things the consumers do NOT share, and which are therefore parameters:
    #
    # * `record_dependencies:` — the ADR-46 cross-file edge. The implicit-self veto genuinely READ the
    #   ancestor's declaration sites to decide a binding, so its walk records them. A dispatch lookup
    #   asking "does some ancestor happen to declare this?" must not be filed as an ancestry edge, which
    #   is exactly what `RbsDispatch.each_source_ancestor_candidate` avoided by reading the raw tables;
    #   threading the flag keeps that property while sharing the walk.
    # * the memo — see {resolve}. The dispatch hot path asks the same `(class, method, kind)` question
    #   for every call site of a class, and the walk is a pure function of the frozen discovery tables
    #   plus the RBS loader, so the answer is cacheable on their identity.
    module ExternalAncestorResolution
      # Thread-local memo store, keyed by the identity of everything the answer depends on:
      # `discovered_superclasses` / `discovered_includes` (the walk) and the RBS loader (the oracle).
      # Modelled on `ExpressionTyper#class_graph_buckets` — the same "a memo that outlives its inputs
      # serves one scope's answer to another" lesson from #682.
      MEMO_KEY = :__rigor_external_ancestor_resolution__
      private_constant :MEMO_KEY

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
      # guessing — which is what the engine answers there now. It is a parameter, and part of the memo
      # key, so that slice lands without re-keying the cache.
      def resolve(class_name, method_name, kind = :instance, scope:, environment: nil, name_memo: nil,
                  record_dependencies: true)
        return nil if class_name.nil? || scope.nil?
        return nil unless kind == :instance

        # Recording is a SIDE EFFECT of the walk, and the memo would swallow it for every file after the
        # first. A normal run never activates the recorder, so the hot path keeps its cache; the
        # incremental-dependency run pays the walk and keeps its edges.
        bucket = memo_bucket(scope, environment) unless record_dependencies && Analysis::DependencyRecorder.active?
        key = [class_name.to_s, method_name.to_sym, kind]
        return bucket[key] if bucket&.key?(key)

        answer = compute(class_name, method_name, kind, scope, environment, name_memo, record_dependencies)
        bucket[key] = answer if bucket
        answer
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

      def compute(class_name, method_name, kind, scope, environment, name_memo, record_dependencies)
        own = method_definition(class_name, method_name, kind, scope: scope, environment: environment)
        if declared_before_object?(own, class_name, scope: scope, environment: environment)
          return [own, class_name.to_s].freeze
        end

        groups = scope.external_ancestor_name_candidates(
          class_name, name_memo: name_memo || {}, record_dependencies: record_dependencies
        )
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
          next if instance_ancestor_names(candidate, scope: scope, environment: environment).empty?

          definition = method_definition(candidate, method_name, kind, scope: scope, environment: environment)
          return nil unless declared_before_object?(definition, candidate, scope: scope, environment: environment)

          return [definition, candidate].freeze
        end
        nil
      end
      private_class_method :first_known_candidate_answer

      def memo_bucket(scope, environment)
        loader = rbs_loader_for(scope, environment)
        return nil if loader.nil?

        store = (Thread.current[MEMO_KEY] ||= {}.compare_by_identity)
        by_super = (store[scope.discovered_superclasses] ||= {}.compare_by_identity)
        by_includes = (by_super[scope.discovered_includes] ||= {}.compare_by_identity)
        by_includes[loader] ||= {}
      end
      private_class_method :memo_bucket

      def rbs_loader_for(scope, environment)
        (environment || scope&.environment)&.rbs_loader
      rescue StandardError
        nil
      end
      private_class_method :rbs_loader_for

      # Drops the thread-local memo. For specs that rebuild an RBS environment in place; a normal run
      # relies on the identity keying instead.
      def reset_memo!
        Thread.current[MEMO_KEY] = nil
      end
    end
  end
end
