# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The dependency-source tier (ADR-10): a method an opt-in gem's source defines answers `Dynamic` from the
      # `Analysis::DependencySourceInference::Index` the environment carries, below every signature and above the
      # discovered-method tier. `MethodDispatcher.resolve` records the origin of its answer, so it is a call there and
      # a member of no tier array.
      #
      # {#dep_source_class_name} is a second entry: the boundary-cross record `resolve` makes after an RBS answer
      # reads the receiver's class the same way.
      module DependencySource
        module_function

        # ADR-10 slice 2b-ii. Consults the per-run `Analysis::DependencySourceInference::Index`
        # carried by the environment for `(class_name, method_name)` observations harvested from
        # opt-in gems' `roots:`. On a hit, returns `Combinator.untyped` so the call site carries
        # the `Dynamic[top]` provenance (per ADR-10's "Inference contract": gem-source-inferred
        # shapes never publish as ground-truth `T`). Returns `nil` when the environment carries no
        # index, the index has no entry, or the receiver has no nominal class to look up.
        def try_dispatch(context)
          receiver_type = context.receiver
          method_name = context.method_name
          environment = context.environment
          index = environment&.dependency_source_index
          return nil if index.nil? || index.empty?

          class_name = dep_source_class_name(receiver_type)
          return nil if class_name.nil?

          # ADR-10 5a — per-receiver plugin veto. When a registered plugin declares
          # `manifest(owns_receivers: [<class>])` AND the call's receiver IS that class (or a
          # subclass), decline and let plugins handle the call. Plugins that own a receiver are
          # the authoritative source for that type; gem-source inference must not contribute
          # behind their backs.
          return nil if plugin_owns_receiver?(class_name, environment)

          contribution = index.contribution_for(class_name: class_name, method_name: method_name)
          return dependency_source_return_type(contribution) if contribution

          # ADR-10 5b — β budget semantics. On a catalog miss, if the receiver class belongs to a
          # budget-exceeded gem AND the user opted into `:dependency_silence`, return
          # `Dynamic[top]` rather than falling through to the user-class fallback. The user-class
          # fallback would otherwise emit `call.undefined-method` for methods Rigor's catalog
          # couldn't reach because the walker hit its cap.
          budget_silence_result(class_name, index, environment)
        end

        # Maps a {DependencySourceInference::Walker::CatalogEntry} to the Type the dispatcher
        # returns at the call site. When the heuristic recovered a static facet, wrap it in
        # `Dynamic[T]` per ADR-10's gem-boundary contract; otherwise fall back to the
        # pre-heuristic `Dynamic[top]`.
        def dependency_source_return_type(contribution)
          return Type::Combinator.untyped if contribution.return_type.nil?

          Type::Combinator.dynamic(contribution.return_type)
        end

        def budget_silence_result(class_name, index, _environment)
          return nil unless index.budget_overrun_strategy == :dependency_silence

          owning_gem = index.gem_for(class_name)
          return nil if owning_gem.nil?
          return nil unless index.budget_exceeded.include?(owning_gem)

          Type::Combinator.untyped
        end

        # ADR-52 WD1 — the per-dispatch plugins × owns_receivers × `class_ordering` walk moved into
        # the compiled contribution table: the union is built once per registry (almost always
        # empty → O(1) false) and per-class verdicts memoise per run.
        def plugin_owns_receiver?(class_name, environment)
          registry = environment&.plugin_registry
          return false if registry.nil? || registry.empty?

          registry.contribution_index.owns_receiver?(class_name, environment)
        end

        def dep_source_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name
          end
        end
      end
    end
  end
end
