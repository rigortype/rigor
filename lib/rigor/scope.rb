# frozen_string_literal: true

require_relative "type"
require_relative "environment"
require_relative "analysis/fact_store"
require_relative "inference/expression_typer"
require_relative "inference/statement_evaluator"

module Rigor
  # Immutable analyzer scope: holds local-variable bindings and a reference
  # to the surrounding Environment. State changes return new scopes through
  # explicit transition methods (#with_local). The central query is
  # #type_of(node), the Rigor counterpart of PHPStan's
  # $scope->getType($node).
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  class Scope
    attr_reader :environment, :locals, :fact_store, :self_type, :declared_types

    EMPTY_DECLARED_TYPES = {}.compare_by_identity.freeze
    private_constant :EMPTY_DECLARED_TYPES

    class << self
      def empty(environment: Environment.default)
        new(environment: environment, locals: {}.freeze, fact_store: Analysis::FactStore.empty)
      end
    end

    def initialize(
      environment:, locals:,
      fact_store: Analysis::FactStore.empty,
      self_type: nil,
      declared_types: EMPTY_DECLARED_TYPES
    )
      @environment = environment
      @locals = locals
      @fact_store = fact_store
      @self_type = self_type
      @declared_types = declared_types
      freeze
    end

    def local(name)
      @locals[name.to_sym]
    end

    def with_local(name, type)
      new_locals = @locals.merge(name.to_sym => type).freeze
      new_fact_store = fact_store.invalidate_target(Analysis::FactStore::Target.local(name))
      self.class.new(
        environment: environment, locals: new_locals,
        fact_store: new_fact_store, self_type: self_type,
        declared_types: declared_types
      )
    end

    def with_fact(fact)
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store.with_fact(fact), self_type: self_type,
        declared_types: declared_types
      )
    end

    # Slice A-engine. Returns a scope with `self_type` set to `type`,
    # preserving locals and facts. `StatementEvaluator` injects this
    # at class-body and method-body boundaries; `ExpressionTyper`
    # consults it when typing `Prism::SelfNode` and implicit-self
    # `Prism::CallNode` receivers.
    def with_self_type(type)
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store, self_type: type,
        declared_types: declared_types
      )
    end

    # Slice A-declarations. Returns a scope that carries an
    # identity-comparing Hash of `Prism::Node => Rigor::Type`
    # overrides. `ExpressionTyper#type_of(node)` MUST consult
    # `declared_types[node]` before any other dispatch and
    # return the recorded type as-is when present. The table is
    # populated by `ScopeIndexer` for declaration-position
    # nodes (the `constant_path` of `Prism::ModuleNode` and
    # `Prism::ClassNode`) so a `module Foo` / `class Bar`
    # header types as `Singleton[<qualified path>]` instead of
    # falling through to `Dynamic[Top]`. The table is shared
    # by structural reference across every derived scope so
    # `with_local` / `with_fact` / `with_self_type` carry it
    # transparently.
    def with_declared_types(table)
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store, self_type: self_type,
        declared_types: table
      )
    end

    def facts_for(target: nil, bucket: nil)
      fact_store.facts_for(target: target, bucket: bucket)
    end

    def local_facts(name, bucket: nil)
      facts_for(target: Analysis::FactStore::Target.local(name), bucket: bucket)
    end

    def type_of(node, tracer: nil)
      Inference::ExpressionTyper.new(scope: self, tracer: tracer).type_of(node)
    end

    # Statement-level evaluation: returns the pair `[type, scope']`
    # where `type` is what the node produces and `scope'` is the
    # scope observable after the node has run. The receiver scope is
    # never mutated. See {Rigor::Inference::StatementEvaluator} for
    # the catalogue of nodes that thread scope; everything else
    # defers to {#type_of} and returns the receiver scope unchanged.
    def evaluate(node, tracer: nil)
      Inference::StatementEvaluator.new(scope: self, tracer: tracer).evaluate(node)
    end

    # Joins this scope with another at a control-flow merge point. The
    # joined scope is bound to every local that BOTH branches bind, with
    # the type widened to the union of both sides. Names bound in only
    # one branch are dropped from the joined scope; the eventual
    # statement-level evaluator (Slice 3 phase 2) is responsible for
    # nil-injecting half-bound names where the language semantics demand
    # it. The two scopes MUST share the same Environment.
    def join(other)
      raise ArgumentError, "join requires a Rigor::Scope, got #{other.class}" unless other.is_a?(Scope)

      unless environment.equal?(other.environment)
        raise ArgumentError, "join requires both scopes to share the same Environment"
      end

      shared = locals.keys & other.locals.keys
      joined_locals = shared.to_h do |name|
        [name, Type::Combinator.union(locals[name], other.locals[name])]
      end
      build_joined_scope(joined_locals, other)
    end

    def ==(other)
      other.is_a?(Scope) &&
        environment.equal?(other.environment) &&
        @locals == other.locals &&
        fact_store == other.fact_store &&
        self_type == other.self_type
    end
    alias eql? ==

    def hash
      [Scope, environment.object_id, @locals, fact_store, self_type].hash
    end

    private

    def build_joined_scope(joined_locals, other)
      self.class.new(
        environment: environment,
        locals: joined_locals.freeze,
        fact_store: fact_store.join(other.fact_store),
        self_type: self_type == other.self_type ? self_type : nil,
        declared_types: declared_types
      )
    end
  end
end
