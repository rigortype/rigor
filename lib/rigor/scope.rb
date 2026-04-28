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
    attr_reader :environment

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

    def locals
      @locals
    end

    def type_of(node, tracer: nil)
      Inference::ExpressionTyper.new(scope: self, tracer: tracer).type_of(node)
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
