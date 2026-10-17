# frozen_string_literal: true

module Rigor
  module Inference
    module RefinedDispatch
      # Issue #1979 — whether a class whose superclass the tables do not know is `class K < <expr>` with `<expr>` a
      # core constructor call (`Data.define(...)`, `Struct.new(...)`, `Class.new(<constant>)`) that cannot answer a
      # given class or one of its subclasses, so a subclass walk may leave it out (`OwnMethod.each_subclass` with
      # `possible_only:`).
      #
      # Each constant the expression names (the indexer's `[DiscoveryIndex::ENVELOPE_CONSTRUCTED_KIND, name]` entries)
      # must be a class the environment knows that is neither the given class nor a subclass of it, and the project
      # must not touch the name: no project class or module whose last segment is the name (Ruby resolves a constant
      # through the enclosing classes' ancestors and mixins too, so a `Base::StandardError` a class inherits may be
      # what `Class.new(StandardError)` names), no reopening, singleton `def`, refinement or method table keyed by
      # the name itself, and no constant write of it. Any other shape answers false, as does a class a
      # `K = Class.new(...)` write names.
      module ConstructedClass
        MEMO_KEY = :__rigor_constructed_class__
        EMPTY = [].freeze
        private_constant :MEMO_KEY, :EMPTY

        module_function

        # True when `name` cannot be `class_name` or a subclass of it. Files `name`'s class edge and a `constant:`
        # edge per named constant on every call; a class declaration appearing fires the walk's `subclass_of:*`.
        def elsewhere?(scope, name, class_name)
          table = memo(scope)
          named = constructed_names(scope, name, table)
          if Analysis::DependencyRecorder.active?
            Scope::ResolutionChain.record_class(scope, name)
            named.each { |constant| Analysis::DependencyRecorder.read_name(:constant, constant) }
          end
          return false if named.empty?

          by_class = (table[:verdicts][class_name] ||= {})
          return by_class[named] if by_class.key?(named)

          by_class[named] = named.all? { |constant| core_class_apart?(scope, constant, class_name.to_s, table) }
        end

        def core_class_apart?(scope, constant, class_name, table)
          environment = scope.environment
          return false unless environment&.class_known?(constant)
          return false if project_name?(scope, constant, table)
          return false unless scope.shadowing_constant_names(constant).empty?

          ordering = environment.class_ordering(constant, class_name)
          %i[disjoint superclass].include?(ordering) ||
            (ordering == :unknown && !environment.class_known?(class_name))
        end

        # Whether the project touches `constant` by name: a declared or reopened class or module whose last segment
        # it is, or a top-level table keyed by it (a singleton `def Data.define`, methods, envelope entries or marks,
        # mixins, a refinement).
        def project_name?(scope, constant, table)
          return true if declared_segments(scope, table).include?(constant)

          discovery = scope.discovery
          [discovery.discovered_classes, discovery.discovered_superclasses, discovery.discovered_includes,
           discovery.discovered_prepends, discovery.discovered_extends, discovery.discovered_methods,
           discovery.discovered_parameter_envelopes, discovery.discovered_refinements].any? do |by_name|
            by_name.key?(constant)
          end
        end

        # The last segment of every class or module the project declares, reopenings included.
        def declared_segments(scope, table)
          table[:segments] ||= declared_names(scope).each_key.to_set { |key| key.to_s.split("::").last }.freeze
        end

        # The constants `name`'s superclass expression names, or an empty Array; memoised per envelope bucket,
        # which a file's own discovery shares with the run's seed for every class it does not declare.
        def constructed_names(scope, name, table)
          bucket = scope.discovered_parameter_envelopes[name]
          return EMPTY if bucket.nil?

          names = table[:names]
          return names[bucket] if names.key?(bucket)

          names[bucket] =
            if bucket.key?(Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK)
              EMPTY
            else
              kind = Scope::DiscoveryIndex::ENVELOPE_CONSTRUCTED_KIND
              bucket.each_key.filter_map { |key| key[1] if key.is_a?(Array) && key[0] == kind }.freeze
            end
        end

        # The run-wide table of declared classes: the seeded `discovered_class_sources`, or a single-file run's
        # `discovered_classes` where nothing seeded it.
        def declared_names(scope)
          sources = scope.discovery.discovered_class_sources
          sources.empty? ? scope.discovery.discovered_classes : sources
        end

        # One thread-local slot keyed on the run-generation token the runner seeds (or, unseeded, the file's merged
        # `discovered_def_nodes`, as `ExpressionTyper` falls back) and the environment: every table read here is
        # fixed for a run, so each answer is computed once a run, and a new run replaces the slot.
        def memo(scope)
          slot = Thread.current[MEMO_KEY]
          generation = scope.run_generation || scope.discovered_def_nodes
          environment = scope.environment
          unless slot && slot[0].equal?(generation) && slot[1].equal?(environment)
            slot = [generation, environment, { names: {}.compare_by_identity, verdicts: {} }]
            Thread.current[MEMO_KEY] = slot
          end
          slot[2]
        end
      end
    end
  end
end
