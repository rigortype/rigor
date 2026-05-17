# frozen_string_literal: true

require_relative "hkt_body"

module Rigor
  module Inference
    # ADR-20 Slice 2a — reducer that walks a `Definition`'s
    # `body_tree` against a concrete `Type::App` and returns a
    # fully-typed `Rigor::Type`.
    #
    # Reduction is the operational interpretation of ADR-20
    # § D4 ("Evaluation rules"):
    #
    # 1. **Resolve `F`.** Look up the registered body via
    #    `registry.definition(uri)`.
    # 2. **Substitute arguments.** Walk the body tree, replacing
    #    `{HktBody::Param}` nodes with the matching positional
    #    arg from the application.
    # 3. **Build types.** `{HktBody::TypeLeaf}` returns its
    #    wrapped type as-is; `{HktBody::Union}` and
    #    `{HktBody::NominalApp}` route their reduced children
    #    through `Type::Combinator.union` / `.nominal_of` so
    #    normalization applies.
    # 4. **Recurse on `{HktBody::AppRef}` nodes.** Reduce the
    #    args first; if the resulting `(uri, args)` matches an
    #    App already on the current reduction stack, return the
    #    in-progress `Type::App` carrier as-is (lazy
    #    self-reference handling — the standard "tying the
    #    knot" trick for recursive type aliases like
    #    `json::value`). Otherwise build a fresh
    #    `Type::App` and recursively reduce it against the
    #    same registry, sharing the fuel budget.
    # 5. **Fuel budget.** Each visited node consumes one unit.
    #    On exhaustion, reduction unwinds to `app.bound`.
    #
    # The reducer is **pure** with respect to its inputs (the
    # registry + the App) but uses a per-call mutable state
    # bag for fuel + cycle tracking. Concurrent reductions
    # MUST allocate fresh reducers (or fresh `_reduce` calls)
    # — the per-call state is not shared.
    class HktReducer
      DEFAULT_FUEL = 64

      class FuelExhausted < StandardError; end

      def initialize(registry)
        raise ArgumentError, "registry must be an HktRegistry" unless registry.is_a?(HktRegistry)

        @registry = registry
      end

      # Reduce `app` against the registry.
      #
      # @param app [Rigor::Type::App]
      # @param fuel [Integer] reduction-step budget (default 64
      #   per ADR-20 WD3). Each visited body node costs one
      #   unit. On exhaustion the reduction returns `app.bound`.
      # @return [Rigor::Type] the reduced type, or `app.bound`
      #   when reduction is impossible (URI not defined, arity
      #   mismatch, body_tree absent, fuel exhausted).
      def reduce(app, fuel: DEFAULT_FUEL)
        raise ArgumentError, "expected a Rigor::Type::App, got #{app.class}" unless app.is_a?(Type::App)

        definition = @registry.definition(app.uri)
        return app.bound if definition.nil? || definition.body_tree.nil?
        return app.bound if definition.params.size != app.args.size

        state = State.new(fuel: fuel)
        begin
          state.with_in_progress(app.uri, app.args, app) do
            walk(definition.body_tree, bindings: bindings_for(definition, app.args), state: state) || app.bound
          end
        rescue FuelExhausted
          app.bound
        end
      end

      private

      def bindings_for(definition, args)
        definition.params.zip(args).to_h
      end

      def walk(node, bindings:, state:)
        state.consume_fuel!

        case node
        when HktBody::TypeLeaf
          node.type
        when HktBody::Param
          bindings.fetch(node.name) do
            raise ArgumentError, "unknown param #{node.name.inspect}; declared: #{bindings.keys}"
          end
        when HktBody::Union
          reduced = node.arms.map { |arm| walk(arm, bindings: bindings, state: state) }
          Type::Combinator.union(*reduced)
        when HktBody::NominalApp
          reduced_args = node.args.map { |arg| walk(arg, bindings: bindings, state: state) }
          Type::Combinator.nominal_of(node.class_name, type_args: reduced_args)
        when HktBody::AppRef
          reduced_args = node.args.map { |arg| walk(arg, bindings: bindings, state: state) }
          reduce_app_ref(node.uri, reduced_args, state: state)
        else
          raise ArgumentError, "unknown body node: #{node.class}"
        end
      end

      def reduce_app_ref(uri, reduced_args, state:)
        # Cycle detection — when the same `(uri, args)` is
        # already on the reduction stack, return the
        # in-progress App carrier as-is so recursive type
        # aliases (`Array[App[json::value, K]]` inside the
        # `json::value` body) terminate.
        existing = state.in_progress_for(uri, reduced_args)
        return existing if existing

        registration = @registry.registration(uri)
        bound = registration&.bound || Type::Combinator.untyped
        new_app = Type::App.new(uri, reduced_args, bound: bound)

        definition = @registry.definition(uri)
        return new_app if definition.nil? || definition.body_tree.nil?
        return new_app if definition.params.size != reduced_args.size

        state.with_in_progress(uri, reduced_args, new_app) do
          walk(definition.body_tree, bindings: bindings_for(definition, reduced_args), state: state) || new_app
        end
      end

      # Per-call mutable bag carrying the remaining fuel
      # budget and the active reduction stack (for cycle
      # detection). Not shared across `reduce` calls.
      class State
        def initialize(fuel:)
          @fuel = fuel
          @in_progress = {}
        end

        def consume_fuel!
          raise FuelExhausted if @fuel <= 0

          @fuel -= 1
        end

        def in_progress_for(uri, args)
          @in_progress[[uri, args]]
        end

        def with_in_progress(uri, args, app)
          key = [uri, args]
          previous = @in_progress[key]
          @in_progress[key] = app
          begin
            yield
          ensure
            if previous.nil?
              @in_progress.delete(key)
            else
              @in_progress[key] = previous
            end
          end
        end
      end
    end
  end
end
