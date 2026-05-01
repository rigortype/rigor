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
  # rubocop:disable Metrics/ClassLength,Metrics/ParameterLists
  class Scope
    attr_reader :environment, :locals, :fact_store, :self_type, :declared_types,
                :ivars, :cvars, :globals, :class_ivars

    EMPTY_DECLARED_TYPES = {}.compare_by_identity.freeze
    EMPTY_VAR_BINDINGS = {}.freeze
    EMPTY_CLASS_IVARS = {}.freeze
    private_constant :EMPTY_DECLARED_TYPES, :EMPTY_VAR_BINDINGS, :EMPTY_CLASS_IVARS

    class << self
      def empty(environment: Environment.default)
        new(environment: environment, locals: {}.freeze, fact_store: Analysis::FactStore.empty)
      end
    end

    def initialize(
      environment:, locals:,
      fact_store: Analysis::FactStore.empty,
      self_type: nil,
      declared_types: EMPTY_DECLARED_TYPES,
      ivars: EMPTY_VAR_BINDINGS,
      cvars: EMPTY_VAR_BINDINGS,
      globals: EMPTY_VAR_BINDINGS,
      class_ivars: EMPTY_CLASS_IVARS
    )
      @environment = environment
      @locals = locals
      @fact_store = fact_store
      @self_type = self_type
      @declared_types = declared_types
      @ivars = ivars
      @cvars = cvars
      @globals = globals
      @class_ivars = class_ivars
      freeze
    end

    def local(name)
      @locals[name.to_sym]
    end

    def with_local(name, type)
      new_locals = @locals.merge(name.to_sym => type).freeze
      new_fact_store = fact_store.invalidate_target(Analysis::FactStore::Target.local(name))
      rebuild(locals: new_locals, fact_store: new_fact_store)
    end

    def with_fact(fact)
      rebuild(fact_store: fact_store.with_fact(fact))
    end

    # Slice A-engine. Returns a scope with `self_type` set to `type`,
    # preserving locals and facts. `StatementEvaluator` injects this
    # at class-body and method-body boundaries; `ExpressionTyper`
    # consults it when typing `Prism::SelfNode` and implicit-self
    # `Prism::CallNode` receivers.
    def with_self_type(type)
      rebuild(self_type: type)
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
      rebuild(declared_types: table)
    end

    # Slice 7 phase 1 — instance/class/global variable bindings.
    # `ivar(name)` / `cvar(name)` / `global(name)` return the
    # type currently bound for the named variable, or `nil` when
    # the variable has not been written in the analyzed slice of
    # the program. The first cut tracks bindings only within a
    # single method body (each `def` enters with a fresh binding
    # map), so reads in other methods of the same class fall
    # through to `Dynamic[Top]`. Cross-method ivar/cvar inference
    # is a follow-up slice.
    def ivar(name)
      @ivars[name.to_sym]
    end

    def cvar(name)
      @cvars[name.to_sym]
    end

    def global(name)
      @globals[name.to_sym]
    end

    def with_ivar(name, type)
      rebuild(ivars: @ivars.merge(name.to_sym => type).freeze)
    end

    def with_cvar(name, type)
      rebuild(cvars: @cvars.merge(name.to_sym => type).freeze)
    end

    def with_global(name, type)
      rebuild(globals: @globals.merge(name.to_sym => type).freeze)
    end

    # Slice 7 phase 2 — class-level ivar accumulator. Keyed by
    # the qualified class name (e.g. `"Rigor::Scope"`); the
    # value is a `Hash[Symbol, Type::t]` of every ivar that
    # appears as a write target inside any def body of that
    # class. `StatementEvaluator#build_method_entry_scope`
    # seeds the method body's `ivars` map from this table so a
    # `def get; @x; end` reads the type written in a sibling
    # `def init; @x = 1; end`.
    #
    # `ScopeIndexer` populates the table once at index time
    # through a separate pre-pass over the program. The map is
    # frozen and shared by structural reference across every
    # derived scope.
    def class_ivars_for(class_name)
      return EMPTY_VAR_BINDINGS if class_name.nil?

      @class_ivars[class_name.to_s] || EMPTY_VAR_BINDINGS
    end

    def with_class_ivars(table)
      rebuild(class_ivars: table)
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

      joined_locals = join_bindings(locals, other.locals)
      joined_ivars = join_bindings(ivars, other.ivars)
      joined_cvars = join_bindings(cvars, other.cvars)
      joined_globals = join_bindings(globals, other.globals)
      build_joined_scope(joined_locals, joined_ivars, joined_cvars, joined_globals, other)
    end

    def ==(other) # rubocop:disable Metrics/CyclomaticComplexity
      other.is_a?(Scope) &&
        environment.equal?(other.environment) &&
        @locals == other.locals &&
        fact_store == other.fact_store &&
        self_type == other.self_type &&
        @ivars == other.ivars &&
        @cvars == other.cvars &&
        @globals == other.globals
    end
    alias eql? ==

    def hash
      [Scope, environment.object_id, @locals, fact_store, self_type, @ivars, @cvars, @globals].hash
    end

    private

    def rebuild(
      locals: @locals, fact_store: @fact_store, self_type: @self_type,
      declared_types: @declared_types, ivars: @ivars, cvars: @cvars, globals: @globals,
      class_ivars: @class_ivars
    )
      self.class.new(
        environment: environment, locals: locals,
        fact_store: fact_store, self_type: self_type,
        declared_types: declared_types,
        ivars: ivars, cvars: cvars, globals: globals,
        class_ivars: class_ivars
      )
    end

    def join_bindings(left, right)
      shared = left.keys & right.keys
      shared.to_h { |name| [name, Type::Combinator.union(left[name], right[name])] }.freeze
    end

    def build_joined_scope(joined_locals, joined_ivars, joined_cvars, joined_globals, other)
      self.class.new(
        environment: environment,
        locals: joined_locals.freeze,
        fact_store: fact_store.join(other.fact_store),
        self_type: self_type == other.self_type ? self_type : nil,
        declared_types: declared_types,
        ivars: joined_ivars,
        cvars: joined_cvars,
        globals: joined_globals,
        class_ivars: class_ivars
      )
    end
  end
  # rubocop:enable Metrics/ClassLength,Metrics/ParameterLists
end
