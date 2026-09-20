# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # ADR-16 Tier A — engine hook. Consults every registered plugin manifest's `block_as_methods`
    # entries to decide whether a block call site qualifies for `Scope#self_type` narrowing.
    #
    # The match contract for a class-level DSL like Sinatra's
    # `class MyApp < Sinatra::Base; get '/foo' do ... end; end`:
    #
    # - the call's lexical receiver type is `Singleton[X]` (the implicit-self in a class body, or
    #   an explicit `MyApp.get(...)` call);
    # - the underlying class `X` equals or inherits from the entry's `receiver_constraint`;
    # - the call's method name is in the entry's `method_names`.
    #
    # On a match the helper returns the narrowed `self_type` for the block body: the receiver class's
    # instance type (`Nominal[X]`) for `:receiver_instance` entries — Sinatra's `generate_method`
    # contract — or the entry's named `self_type` class when the DSL `instance_eval`s the block on a
    # different object (Grape's `params` body on `Grape::Validations::ParamsScope`, `namespace` body on
    # the `Grape::API::Instance` class object, verb bodies on `Grape::Endpoint`).
    #
    # Slice 1b ships the floor only (per ADR-16 § WD13): bare-identifier method lookups inside the
    # block resolve through the inference engine's normal `self_type`-driven path, so methods
    # declared on `Sinatra::Base` (RBS or otherwise) become visible. Precision additions —
    # parameter-typed block params, declared per-verb argument contracts — are ceiling concerns
    # for later slices.
    module MacroBlockSelfType
      module_function

      # @return the narrowed self-type, or
      #   `nil` when no registered entry matches the call shape.
      def narrow_self_type_for(scope:, call_node:, receiver_type:)
        return nil if receiver_type.nil?

        environment = scope&.environment
        registry = environment&.plugin_registry
        return nil if registry.nil? || registry.empty?

        singleton_name = singleton_receiver_class_name(receiver_type)
        nominal_name = nominal_receiver_class_name(receiver_type)
        return nil if singleton_name.nil? && nominal_name.nil?

        # ADR-52 WD1 — the verb-keyed table compiled at registry build. Entries arrive in
        # (plugin registration, declaration) order; the method-name membership is guaranteed
        # by the table key.
        entries = registry.contribution_index.block_entries_for(call_node.name)
        entries.each do |entry|
          narrowed = entry_self_type_for(entry, singleton_name, nominal_name, scope, environment)
          return narrowed if narrowed
        end
        nil
      end

      # The narrowed `self_type` one entry contributes for this receiver, or nil on a miss. Nominal
      # receivers exist only inside an already-narrowed `instance_eval` body — they can only re-enter a
      # *named instance*-binding entry (`params`-family nesting on `Nominal[ParamsScope]`).
      # `:receiver_instance` and `singleton(...)` entries keep their Singleton-only contract.
      def entry_self_type_for(entry, singleton_name, nominal_name, scope, environment)
        return nil if singleton_name.nil? && !entry.named_instance_binding?

        receiver_name = singleton_name || nominal_name
        matched = receiver_class_inherits_from?(receiver_name, entry.receiver_constraint, environment, scope)
        # `extend M` lifts M's instance surface onto the class object — `class F; extend T::Sig;
        # sig { ... }; end` calls `sig` on `Singleton[F]` even though F does not INHERIT from
        # T::Sig. Singleton receivers therefore also match through the extends edge.
        if !matched && singleton_name
          matched = singleton_extends_reach?(receiver_name, entry.receiver_constraint, scope, environment)
        end
        return nil unless matched

        narrowed_self_type(entry, receiver_name, environment)
      end

      # The match contract stays narrow: `Singleton[X]` receivers (class-level DSL calls) for every
      # entry, plus `Nominal[Y]` receivers only for entries whose declared `self_type` binds an
      # instance — the `requires do ... requires do ... end` nesting shape inside a Grape `params`
      # body, where `self` is already the ParamsScope instance the call evaluates on.
      def singleton_receiver_class_name(receiver_type)
        return nil unless receiver_type.is_a?(Type::Singleton)

        receiver_type.class_name
      end

      def nominal_receiver_class_name(receiver_type)
        return nil unless receiver_type.is_a?(Type::Nominal)

        receiver_type.class_name
      end

      # The narrowed `self_type` an entry contributes: `:receiver_instance` keeps the receiver class's
      # instance type; a String `self_type` names the class the DSL `instance_eval`s the block on —
      # `singleton(Foo)` for class-object evaluation (Grape's `namespace` body on
      # `Grape::API::Instance`), `Foo` for instance evaluation (Grape's verb bodies on
      # `Grape::Endpoint`, `params` bodies on `Grape::Validations::ParamsScope`).
      def narrowed_self_type(entry, receiver_class_name, environment)
        self_type = entry.self_type
        return instance_type_for(receiver_class_name, environment) if self_type == :receiver_instance

        if entry.singleton_binding?
          return environment.singleton_for_name(entry.self_type_name) || Type::Singleton.new(entry.self_type_name)
        end

        instance_type_for(entry.self_type_name, environment)
      end

      def receiver_class_inherits_from?(class_name, constraint, environment, scope = nil)
        name = class_name.to_s
        return true if name == constraint
        return true if rbs_inherits?(name, constraint, environment)

        # Source-side ancestry — `class API < Grape::API` lives on the scope's discovery tables, not in
        # the environment's RBS/registry ordering (the same reason ADR-43's bridge walks them).
        source_ancestors_reach?(name, constraint, environment, scope)
      rescue StandardError
        false
      end

      # BFS over the source-side superclass table. The table stores names AS WRITTEN (`"::API::Base"`,
      # bare `"Base"`), so each hop resolves through `ancestor_name_candidates` (rooted names, header
      # nesting) rather than a raw lookup. Deliberately NOT `external_ancestor_name_candidates`: that
      # walk records `ancestry_sources` edges through `record_class_dependency`, which would mislabel
      # a DSL-call lookup as an ancestry dependency.
      def source_ancestors_reach?(name, constraint, environment, scope)
        supers = scope&.discovered_superclasses
        queue = [name]
        seen = {}
        until queue.empty?
          current = queue.shift
          next if current.nil? || seen[current]

          seen[current] = true
          raw = supers&.[](current)
          next if raw.nil?

          scope.ancestor_name_candidates(current, raw).each do |candidate|
            return true if candidate == constraint || rbs_inherits?(candidate, constraint, environment)

            queue << candidate if supers.key?(candidate)
          end
        end
        false
      end

      # The `extend`-edge twin of `source_ancestors_reach?`: true when `class_name` — or one of its
      # discovered superclasses — extends a module resolving to `constraint`. Source `extend` targets
      # arrive as-written and resolve through `ancestor_name_candidates`; RBS-side `extend` edges come
      # from `Environment#singleton_extended_modules`, which is how `class Doc < T::Struct` picks up
      # `T::Struct`'s own `extend T::Sig`. A candidate that resolves to a project class or a different
      # RBS name owns the edge — the source-extend fold already handles project modules — so the walk
      # stops consulting that edge's remaining fallbacks.
      def singleton_extends_reach?(class_name, constraint, scope, environment)
        return false if scope.nil?

        supers = scope.discovered_superclasses
        extends = scope.discovered_extends
        queue = [class_name.to_s]
        seen = {}
        until queue.empty?
          current = queue.shift
          next if current.nil? || seen[current]

          seen[current] = true
          return true if extended_module_matches?(current, extends, constraint, scope, environment)

          raw = supers[current]
          scope.ancestor_name_candidates(current, raw).each { |c| queue << c } if raw
        end
        false
      rescue StandardError
        false
      end

      # One walk hop of `singleton_extends_reach?`: true when `current` extends a module resolving
      # to `constraint`, consulting the source extend table first then the RBS singleton-extension
      # side. A candidate resolving to a project class or a different RBS name owns its edge.
      def extended_module_matches?(current, extends, constraint, scope, environment)
        (extends[current] || []).each do |mod_name|
          scope.ancestor_name_candidates(current, mod_name).each do |candidate|
            return true if candidate == constraint || rbs_inherits?(candidate, constraint, environment)
            break if scope.known_user_class?(candidate) ||
                     Rigor::Reflection.rbs_class_known?(candidate, environment: environment)
          end
        end
        (environment.singleton_extended_modules(current) || []).any? do |mod_name|
          mod_name == constraint || rbs_inherits?(mod_name, constraint, environment)
        end
      end

      def rbs_inherits?(class_name, constraint, environment)
        %i[equal subclass].include?(environment.class_ordering(class_name, constraint))
      end

      def instance_type_for(class_name, environment)
        environment.nominal_for_name(class_name) || Type::Nominal.new(class_name)
      end
    end
  end
end
