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
      # must not touch the name at all: no project class, module, reopening, singleton `def`, refinement or method
      # table whose last segment is the name (Ruby resolves a constant through the enclosing classes' ancestors and
      # mixins too, so a `Base::StandardError` a class inherits may be what `Class.new(StandardError)` names), and
      # no constant write of it. Any other shape answers false, as does a class a `K = Class.new(...)` write names.
      module ConstructedClass
        MEMO_KEY = :__rigor_constructed_class__
        private_constant :MEMO_KEY

        module_function

        # True when `name` cannot be `class_name` or a subclass of it. Files `name`'s class edge and a `constant:`
        # edge per named constant on every call; a class declaration appearing fires the walk's `subclass_of:*`.
        def elsewhere?(scope, name, class_name)
          named = constructed_names(scope, name)
          if Analysis::DependencyRecorder.active?
            Scope::ResolutionChain.record_class(scope, name)
            named.each { |constant| Analysis::DependencyRecorder.read_name(:constant, constant) }
          end
          return false if named.empty?

          verdicts = memo(scope)[:verdicts]
          key = [name, class_name.to_s]
          return verdicts[key] if verdicts.key?(key)

          verdicts[key] = named.all? { |constant| core_class_apart?(scope, constant, class_name.to_s) }
        end

        def core_class_apart?(scope, constant, class_name)
          environment = scope.environment
          return false unless environment&.class_known?(constant)
          return false if project_segments(scope).include?(constant)
          return false unless scope.shadowing_constant_names(constant).empty?

          ordering = environment.class_ordering(constant, class_name)
          %i[disjoint superclass].include?(ordering) ||
            (ordering == :unknown && !environment.class_known?(class_name))
        end

        # The constants `name`'s superclass expression names, or an empty Array.
        def constructed_names(scope, name)
          cache = memo(scope)[:names]
          return cache[name] if cache.key?(name)

          bucket = scope.discovered_parameter_envelopes[name]
          cache[name] =
            if bucket.nil? || bucket.key?(Scope::DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK)
              [].freeze
            else
              kind = Scope::DiscoveryIndex::ENVELOPE_CONSTRUCTED_KIND
              bucket.each_key.filter_map { |key| key[1] if key.is_a?(Array) && key[0] == kind }.freeze
            end
        end

        # The last segment of every name a project table keys: a declared or reopened class or module, a class
        # with methods, singleton `def`s (`def Data.define`), envelope entries or marks, mixins, or refinements.
        def project_segments(scope)
          table = memo(scope)
          table[:segments] ||= begin
            discovery = scope.discovery
            tables = [discovery.discovered_classes, discovery.discovered_class_sources,
                      discovery.discovered_superclasses, discovery.discovered_includes,
                      discovery.discovered_prepends, discovery.discovered_extends, discovery.discovered_methods,
                      discovery.discovered_def_nodes, discovery.discovered_singleton_def_nodes,
                      discovery.discovered_parameter_envelopes, discovery.discovered_refinements]
            segments = Set.new
            tables.each { |by_name| by_name.each_key { |key| segments << key.to_s.split("::").last } }
            segments.freeze
          end
        end

        # One thread-local slot keyed on the discovery index's and the environment's identity, the shape
        # `Scope::ResolutionChain.for` uses: every answer here is a pure function of the two.
        def memo(scope)
          slot = Thread.current[MEMO_KEY]
          discovery = scope.discovery
          environment = scope.environment
          unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
            slot = [discovery, environment, { names: {}, verdicts: {} }]
            Thread.current[MEMO_KEY] = slot
          end
          slot[2]
        end
      end
    end
  end
end
