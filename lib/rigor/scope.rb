# frozen_string_literal: true

require_relative "type"
require_relative "environment"
require_relative "inference/expression_typer"

module Rigor
  # Immutable analyzer scope: holds local-variable bindings and a reference
  # to the surrounding Environment. State changes return new scopes through
  # explicit transition methods (#with_local). The central query is
  # #type_of(node), the Rigor counterpart of PHPStan's
  # $scope->getType($node).
  #
  # See docs/internal-spec/inference-engine.md for the binding contract.
  class Scope
    attr_reader :environment, :locals

    class << self
      def empty(environment: Environment.default)
        new(environment: environment, locals: {}.freeze)
      end
    end

    def initialize(environment:, locals:)
      @environment = environment
      @locals = locals
      freeze
    end

    def local(name)
      @locals[name.to_sym]
    end

    def with_local(name, type)
      new_locals = @locals.merge(name.to_sym => type).freeze
      self.class.new(environment: environment, locals: new_locals)
    end

    def type_of(node, tracer: nil)
      Inference::ExpressionTyper.new(scope: self, tracer: tracer).type_of(node)
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
      self.class.new(environment: environment, locals: joined_locals.freeze)
    end

    def ==(other)
      other.is_a?(Scope) && environment.equal?(other.environment) && @locals == other.locals
    end
    alias eql? ==

    def hash
      [Scope, environment.object_id, @locals].hash
    end
  end
end
